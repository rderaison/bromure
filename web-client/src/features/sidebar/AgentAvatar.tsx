// AgentAvatar, AgentGlyph, AgentStatusDot, UnreadMark — ports of the Swift
// views (AgentSessions.swift AgentAvatar; SharedStatusViews.swift
// AgentStatusDot / UnreadMark) and the bundled agent glyphs
// (Sources/AgentCoding/Resources/icons/<agent>.svg, inlined here — the same
// artwork, so they're the real Bromure marks, not stand-ins).
// Exported for the stage / rooms / palette too.

import React from 'react';
import type { AgentStatus } from './model';

const STROKE: Record<string, { w: number; d: React.ReactNode }> = {
  claude: { w: 22, d: <><path d="M128 34v188" /><path d="M34 128h188" /><path d="M62 62l132 132" /><path d="M194 62L62 194" /></> },
  codex: { w: 20, d: <><path d="M92 74 L42 128 L92 182" /><path d="M164 74 L214 128 L164 182" /><path d="M150 60 L106 196" /></> },
  grok: { w: 20, d: <><circle cx="128" cy="128" r="82" /><path d="M170 86 L92 164" /></> },
  hermes: { w: 20, d: <><path d="M36 122 L220 40 L172 218 L124 146 Z" /><path d="M124 146 L220 40" /></> },
  kimi: { w: 20, d: <path d="M128 46 A82 82 0 0 0 128 210 A52 82 0 0 1 128 46 Z" /> },
  omp: { w: 20, d: <><path d="M40 74 L96 74 L160 182 L216 182" /><path d="M150 74 L216 74" /></> },
  robot: { w: 12, d: <>
    <circle cx="128" cy="42" r="17" /><path d="M128 59v24" /><path d="M111 88h34" />
    <path d="M54 117h-5c-8 0-14 6-14 14v25c0 8 6 14 14 14h5" /><path d="M202 117h5c8 0 14 6 14 14v25c0 8-6 14-14 14h-5" />
    <rect x="54" y="92" width="148" height="94" rx="37" /><rect x="77" y="114" width="102" height="48" rx="20" />
    <path d="M104 131v16" /><path d="M152 131v16" />
    <path d="M93 204l-25 16 25 16" /><path d="M163 204l25 16-25 16" /><path d="M139 199l-22 44" />
  </> },
};

/** An agent's tab glyph (SVGIcon(name: tool)) — currentColor strokes. */
export function AgentGlyph({ tool, size = 13, color, style }: { tool: string; size?: number; color?: string; style?: React.CSSProperties }) {
  const g = STROKE[tool] ?? STROKE.robot;
  return (
    <svg viewBox="0 0 256 256" width={size} height={size} fill="none" stroke={color ?? 'currentColor'} strokeWidth={g.w}
         strokeLinecap="round" strokeLinejoin="round" style={{ flexShrink: 0, display: 'block', ...style }} aria-hidden>
      {g.d}
    </svg>
  );
}

export const AGENT_TINT: Record<string, string> = {
  claude: '#D97757', codex: '#2B2B2E', grok: '#4B5563', kimi: '#4F46E5', omp: '#0E9F6E', hermes: '#7C5CFF',
};

export const STATUS_COLOR: Record<AgentStatus, string> = { working: 'var(--orange)', done: 'var(--green)', needsInput: 'var(--red)' };
const STATUS_HELP: Record<AgentStatus, string> = { working: 'Working…', done: 'Done', needsInput: 'Needs your input' };

/** The small status dot riding an agent's icon; orange pulses. */
export function AgentStatusDot({ status, scale = 1, style }: { status: AgentStatus; scale?: number; style?: React.CSSProperties }) {
  return (
    <span className={'agent-dot' + (status === 'working' ? ' pulse' : '')} title={STATUS_HELP[status]}
          style={{ background: STATUS_COLOR[status], transform: scale !== 1 ? `scale(${scale})` : undefined, ...style }} />
  );
}

/** The agent's tile: a tinted rounded square with its white glyph. */
export function AgentAvatar({ tool, size = 26, status, style }: { tool: string; size?: number; status?: AgentStatus | null; style?: React.CSSProperties }) {
  return (
    <span className="agent-avatar" style={{ width: size, height: size, ...style }}>
      <span className="agent-avatar-tile" style={{ width: size, height: size, borderRadius: size * 0.27, background: AGENT_TINT[tool] ?? '#4B5563' }}>
        <AgentGlyph tool={tool} size={size * 0.58} color="#fff" />
      </span>
      {status && <AgentStatusDot status={status} scale={size >= 24 ? 1.25 : 1} style={{ position: 'absolute', right: -2, bottom: -2 }} />}
    </span>
  );
}

/** A reply nobody has read: a slowly turning orb. */
export function UnreadMark({ size = 9, style }: { size?: number; style?: React.CSSProperties }) {
  return <span className="unread-mark" title="Unread" aria-label="Unread" style={{ width: size, height: size, ...style }} />;
}
