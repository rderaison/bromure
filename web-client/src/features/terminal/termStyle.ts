// The terminal's look — TerminalAppDefaults.ghosttyConfig for the web.
//
// The macOS surface is libghostty configured from the workspace's appearance
// (fontFamily / fontSize / backgroundHex / foregroundHex in the /state
// workspace record), falling back to this device's Terminal.app defaults —
// and, where those can't be read (iOS, here), TerminalAppDefaults.fallback:
// JetBrains Mono 14, #0d1117 on #c9d1d9. The 16-colour palette is ghostty's
// built-in default (no theme is set in the generated config). Cursor: bar,
// not blinking. Padding: ghostty's default window-padding 2 pt.

import type { ITheme } from '@xterm/xterm';
import type { Workspace } from '../../core/remote/types';

export const FALLBACK = { fontFamily: 'JetBrains Mono', fontSize: 14, background: '#0d1117', foreground: '#c9d1d9' };

/** ghostty's default palette (src/terminal/color.zig `default`). */
export const GHOSTTY_PALETTE = [
  '#1d1f21', '#cc6666', '#b5bd68', '#f0c674', '#81a2be', '#b294bb', '#8abeb7', '#c5c8c6',
  '#666666', '#d54e53', '#b9ca4a', '#e7c547', '#7aa6da', '#c397d8', '#70c0b1', '#eaeaea',
];

export const PADDING = 2;

export interface TermStyle { fontFamily: string; fontSize: number; background: string; foreground: string }

export function resolveStyle(ws: Workspace | undefined): TermStyle {
  const raw = (ws?.fontFamily as string | undefined) ?? FALLBACK.fontFamily;
  const family = !raw || raw.startsWith('.') ? 'JetBrains Mono' : raw;
  const hex = (v: unknown, d: string) => typeof v === 'string' && /^#?[0-9a-f]{6}$/i.test(v) ? (v.startsWith('#') ? v : '#' + v) : d;
  return {
    fontFamily: family,
    fontSize: typeof ws?.fontSize === 'number' && ws.fontSize >= 6 && ws.fontSize <= 72 ? ws.fontSize : FALLBACK.fontSize,
    background: hex(ws?.backgroundHex, FALLBACK.background),
    foreground: hex(ws?.foregroundHex, FALLBACK.foreground),
  };
}

/** CSS font stack: the configured family, then fixed-pitch faces every OS
 *  has (ghostty falls back to Menlo when the family isn't fixed-pitch). */
export function fontStack(family: string) {
  const q = (f: string) => /^[\w-]+$/.test(f) ? f : `"${f.replace(/"/g, '')}"`;
  return [q(family), '"JetBrains Mono"', '"SF Mono"', 'Menlo', '"Cascadia Mono"', '"DejaVu Sans Mono"', 'Consolas', 'monospace']
    .filter((v, i, a) => a.indexOf(v) === i).join(', ');
}

function mix(a: string, b: string, t: number) {
  const p = (h: string) => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
  const [x, y] = [p(a), p(b)];
  return '#' + x.map((v, i) => Math.round(v + (y[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

export function xtermTheme(s: TermStyle): ITheme {
  const [black, red, green, yellow, blue, magenta, cyan, white,
         brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite] = GHOSTTY_PALETTE;
  return {
    background: s.background, foreground: s.foreground,
    // ghostty: cursor = foreground, selection = inverted fg/bg.
    cursor: s.foreground, cursorAccent: s.background,
    selectionBackground: s.foreground, selectionForeground: s.background,
    selectionInactiveBackground: mix(s.background, s.foreground, 0.45),
    black, red, green, yellow, blue, magenta, cyan, white,
    brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite,
    scrollbarSliderBackground: 'rgba(255,255,255,0.18)',
    scrollbarSliderHoverBackground: 'rgba(255,255,255,0.30)',
    scrollbarSliderActiveBackground: 'rgba(255,255,255,0.38)',
  };
}
