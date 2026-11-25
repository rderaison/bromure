// React wrappers for the macOS controls in kit.css. Keep this dependency-free
// and generic: surface-specific widgets live with their surface.

import React, { useEffect, useLayoutEffect, useRef, useState, createContext, useContext, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { SF } from '../icons';

export function cx(...c: (string | false | null | undefined)[]) { return c.filter(Boolean).join(' '); }

// ── Buttons ───────────────────────────────────────────────────────────────

type BtnProps = React.ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: 'default' | 'prominent' | 'borderless' | 'link' | 'icon';
  size?: 'mini' | 'small' | 'regular' | 'large';
  destructive?: boolean;
  icon?: string;
};
export function Button({ variant = 'default', size = 'regular', destructive, icon, className, children, ...rest }: BtnProps) {
  return (
    <button {...rest} className={cx('btn', variant !== 'default' && variant, size !== 'regular' && size, destructive && 'destructive', className)}>
      {icon && <SF name={icon} size={size === 'small' ? 12 : 14} />}
      {children}
    </button>
  );
}

// ── Pop-up button (Picker with .menu style) ──────────────────────────────

export interface Option<T extends string | number = string> { value: T; label: string; disabled?: boolean; divider?: boolean }
export function PopUp<T extends string | number>({ value, options, onChange, disabled, bordered, className, style, title }: {
  value: T; options: Option<T>[]; onChange: (v: T) => void; disabled?: boolean; bordered?: boolean;
  className?: string; style?: React.CSSProperties; title?: string;
}) {
  const cur = options.find(o => o.value === value);
  return (
    <span className={cx('popup', bordered && 'bordered', disabled && 'disabled', className)} style={style} title={title}>
      <span className="popup-label">{cur?.label ?? String(value ?? '')}</span>
      <span className="popup-chev"><SF name="chevron.up.chevron.down" size={11} weight={600} /></span>
      <select value={String(value)} disabled={disabled}
              onChange={e => {
                const o = options.find(o => String(o.value) === e.target.value);
                if (o) onChange(o.value);
              }}>
        {options.map((o, i) => o.divider
          ? <option key={'d' + i} disabled>──────────</option>
          : <option key={String(o.value)} value={String(o.value)} disabled={o.disabled}>{o.label}</option>)}
      </select>
    </span>
  );
}

// ── Switch / checkbox ─────────────────────────────────────────────────────

export function Switch({ checked, onChange, disabled, size = 'small', title }: {
  checked: boolean; onChange?: (v: boolean) => void; disabled?: boolean; size?: 'small' | 'regular'; title?: string;
}) {
  return (
    <span className={cx('switch', size === 'regular' && 'regular')} title={title}>
      <input type="checkbox" role="switch" checked={checked} disabled={disabled} onChange={e => onChange?.(e.target.checked)} />
      <span className="track" /><span className="thumb" />
    </span>
  );
}

export function Checkbox({ checked, onChange, disabled, children }: {
  checked: boolean; onChange?: (v: boolean) => void; disabled?: boolean; children?: React.ReactNode;
}) {
  return (
    <label className="check">
      <input type="checkbox" checked={checked} disabled={disabled} onChange={e => onChange?.(e.target.checked)} />
      {children && <span>{children}</span>}
    </label>
  );
}

// ── Text fields ───────────────────────────────────────────────────────────

export const TextField = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement> & { plain?: boolean; mono?: boolean }>(
  function TextField({ plain, mono, className, ...rest }, ref) {
    return <input ref={ref} spellCheck={false} autoComplete="off" {...rest} className={cx('field', plain && 'plain', mono && 'mono', className)} />;
  });

export function SearchField({ value, onChange, placeholder = 'Search', autoFocus, style, onKeyDown }: {
  value: string; onChange: (v: string) => void; placeholder?: string; autoFocus?: boolean; style?: React.CSSProperties;
  onKeyDown?: React.KeyboardEventHandler<HTMLInputElement>;
}) {
  return (
    <div className="search" style={style}>
      <SF name="magnifyingglass" size={13} />
      <input value={value} placeholder={placeholder} autoFocus={autoFocus} spellCheck={false}
             onChange={e => onChange(e.target.value)} onKeyDown={onKeyDown} />
      {value && <span onClick={() => onChange('')} style={{ display: 'grid' }}><SF name="xmark.circle.fill" size={13} /></span>}
    </div>
  );
}

// ── Segmented control ─────────────────────────────────────────────────────

export function Segmented<T extends string>({ value, options, onChange, large }: {
  value: T; options: { value: T; label: React.ReactNode }[]; onChange: (v: T) => void; large?: boolean;
}) {
  return (
    <div className={cx('segmented', large && 'large')}>
      {options.map(o => (
        <button key={o.value} className={cx(o.value === value && 'on')} onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
}

// ── Grouped form ──────────────────────────────────────────────────────────

export function Form({ children, style }: { children: React.ReactNode; style?: React.CSSProperties }) {
  return <div className="form" style={style}>{children}</div>;
}
export function Section({ title, footer, children, header }: {
  title?: React.ReactNode; footer?: React.ReactNode; children: React.ReactNode; header?: React.ReactNode;
}) {
  return (
    <>
      {title && <div className="form-section-title">{title}</div>}
      <div className="form-section">
        {header}
        {children}
      </div>
      {footer && <div className="form-section-footer">{footer}</div>}
    </>
  );
}
export function Row({ label, sub, children, style }: {
  label?: React.ReactNode; sub?: React.ReactNode; children?: React.ReactNode; style?: React.CSSProperties;
}) {
  return (
    <div className="form-row" style={style}>
      {label !== undefined && <div className="form-label">{label}{sub && <div className="form-sub">{sub}</div>}</div>}
      {children !== undefined && <div className="form-control">{children}</div>}
    </div>
  );
}

// ── Menus ─────────────────────────────────────────────────────────────────

export interface MenuItem {
  label?: string; icon?: string; shortcut?: string; checked?: boolean; disabled?: boolean; destructive?: boolean;
  separator?: boolean; header?: string; action?: () => void; submenu?: MenuItem[];
}

interface MenuState { x: number; y: number; items: MenuItem[]; minWidth?: number }
const MenuCtx = createContext<(m: MenuState | null) => void>(() => {});

export function MenuHost({ children }: { children: React.ReactNode }) {
  const [menu, setMenu] = useState<MenuState | null>(null);
  return (
    <MenuCtx.Provider value={setMenu}>
      {children}
      {menu && <MenuView state={menu} close={() => setMenu(null)} />}
    </MenuCtx.Provider>
  );
}

/** Returns `open(event|rect, items)` for context menus and pull-down buttons. */
export function useMenu() {
  const set = useContext(MenuCtx);
  return useCallback((at: { clientX: number; clientY: number } | DOMRect, items: MenuItem[], minWidth?: number) => {
    const p = 'clientX' in at ? { x: at.clientX, y: at.clientY } : { x: at.left, y: at.bottom + 4 };
    set({ ...p, items, minWidth });
  }, [set]);
}

function MenuView({ state, close }: { state: MenuState; close: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ x: state.x, y: state.y });
  useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const r = el.getBoundingClientRect();
    setPos({ x: Math.max(4, Math.min(state.x, window.innerWidth - r.width - 4)),
             y: Math.max(4, Math.min(state.y, window.innerHeight - r.height - 4)) });
  }, [state]);
  useEffect(() => {
    const onDown = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) close(); };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') close(); };
    setTimeout(() => window.addEventListener('mousedown', onDown), 0);
    window.addEventListener('keydown', onKey);
    window.addEventListener('blur', close);
    return () => { window.removeEventListener('mousedown', onDown); window.removeEventListener('keydown', onKey); window.removeEventListener('blur', close); };
  }, [close]);
  return createPortal(
    <div ref={ref} className="menu" style={{ left: pos.x, top: pos.y, minWidth: state.minWidth }} onContextMenu={e => e.preventDefault()}>
      {state.items.map((it, i) => it.separator ? <div key={i} className="menu-sep" />
        : it.header ? <div key={i} className="menu-header">{it.header}</div>
        : (
          <div key={i} className={cx('menu-item', it.disabled && 'disabled', it.destructive && 'destructive')}
               onMouseUp={() => { if (it.disabled) return; close(); it.action?.(); }}>
            {state.items.some(x => x.checked !== undefined) && <span className="menu-check">{it.checked ? <SF name="checkmark" size={11} weight={700} /> : null}</span>}
            {it.icon && <SF name={it.icon} size={14} />}
            <span>{it.label}</span>
            {it.shortcut && <span className="menu-shortcut">{it.shortcut}</span>}
          </div>
        ))}
    </div>, document.body);
}

// ── Popover ───────────────────────────────────────────────────────────────

export function Popover({ anchor, onClose, children, width, edge = 'bottom' }: {
  anchor: DOMRect; onClose: () => void; children: React.ReactNode; width?: number; edge?: 'bottom' | 'top' | 'right';
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number }>({ left: anchor.left, top: anchor.bottom + 8 });
  useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const r = el.getBoundingClientRect();
    let left = edge === 'right' ? anchor.right + 8 : anchor.left + anchor.width / 2 - r.width / 2;
    let top = edge === 'top' ? anchor.top - r.height - 8 : edge === 'right' ? anchor.top : anchor.bottom + 8;
    left = Math.max(6, Math.min(left, window.innerWidth - r.width - 6));
    top = Math.max(6, Math.min(top, window.innerHeight - r.height - 6));
    setPos({ left, top });
  }, [anchor, edge]);
  useEffect(() => {
    const onDown = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) onClose(); };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    setTimeout(() => window.addEventListener('mousedown', onDown), 0);
    window.addEventListener('keydown', onKey);
    return () => { window.removeEventListener('mousedown', onDown); window.removeEventListener('keydown', onKey); };
  }, [onClose]);
  return createPortal(<div ref={ref} className="popover" style={{ ...pos, width }}>{children}</div>, document.body);
}

// ── Sheet (modal over the window) ─────────────────────────────────────────

export function Sheet({ children, width, onClose, height }: { children: React.ReactNode; width: number; height?: number; onClose?: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose?.(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);
  return createPortal(
    <div className="sheet-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) onClose?.(); }}>
      <div className="sheet" style={{ width, height }}>{children}</div>
    </div>, document.body);
}

// ── Misc ──────────────────────────────────────────────────────────────────

export function Spinner({ size = 14 }: { size?: number }) {
  return <span className="progress-spin" style={{ width: size, height: size }} />;
}

export function Badge({ count, color }: { count: number; color?: string }) {
  if (!count) return null;
  return <span className="badge" style={color ? { background: color } : undefined}>{count}</span>;
}

/** A SwiftUI `.help()` tooltip (shows after a delay like AppKit's). */
export function useTooltip() {
  const [tip, setTip] = useState<{ text: string; x: number; y: number } | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const bind = (text?: string) => text ? {
    onMouseEnter: (e: React.MouseEvent) => {
      const x = e.clientX, y = e.clientY;
      clearTimeout(timer.current);
      timer.current = setTimeout(() => setTip({ text, x, y: y + 18 }), 900);
    },
    onMouseLeave: () => { clearTimeout(timer.current); setTip(null); },
  } : {};
  const node = tip ? createPortal(<div className="tooltip" style={{ left: tip.x, top: tip.y }}>{tip.text}</div>, document.body) : null;
  return { bind, node };
}

/** Links built from untrusted text (agent transcripts, task bodies, PR URLs):
 *  only web and mail links are clickable; anything else renders inert. */
export function safeHref(url: string | undefined | null): string | undefined {
  if (!url) return undefined;
  try {
    const u = new URL(url, 'https://invalid.invalid/');
    if (u.origin === 'https://invalid.invalid') return undefined;   // relative: no meaning here
    return ['http:', 'https:', 'mailto:'].includes(u.protocol) ? u.href : undefined;
  } catch { return undefined; }
}
