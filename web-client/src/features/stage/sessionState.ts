// Stage-only session helpers. The bucketing itself (SessionHome.bucket etc.)
// lives in the sidebar's model (src/features/sidebar/model.ts) — shared.

import { agentKind } from '../newsession/agents';
import type { AgentSession } from '../../core/remote/types';
import {
  bucket, bucketTitle, isArchived, isLaunching, isStartingUp, lastActivity, statusLine,
  type Bucket, type ListModel,
} from '../sidebar/model';

export type { Bucket };

/** SessionBucket.tint as a CSS color. */
export function bucketTint(b: Bucket): string {
  switch (b) {
    case 'needsYou': return 'var(--red)';
    case 'working': return 'var(--orange)';
    case 'idle': return 'var(--green)';
    default: return 'var(--label-secondary)';
  }
}

/** SessionHome.elapsed(since:) — the header's longer form ("7 min"). */
export function elapsed(since?: number, now = Date.now()): string | null {
  if (since == null || isNaN(since)) return null;
  const s = Math.max(0, Math.floor((now - since) / 1000));
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min`;
  if (s < 86400) return `${Math.floor(s / 3600)} h`;
  return `${Math.floor(s / 86400)} d`;
}

/** SessionHeaderView.statusText. */
export function headerStatusText(s: AgentSession, m: ListModel): string {
  const b = bucket(s, m);
  if (isLaunching(s) || (b === 'working' && isStartingUp(s, m.now)) || s.lastError) return statusLine(s, m);
  let detail: string | null = null;
  if (b === 'idle') detail = elapsed(lastActivity(s), m.now);
  else if (b === 'ended') {
    const e = elapsed(s.endedAt ? Date.parse(s.endedAt) : undefined, m.now);
    detail = e ? (e === 'just now' ? e : `${e} ago`) : null;
  }
  const title = b === 'ended' && isArchived(s) ? 'Archived' : bucketTitle[b];
  return detail ? `${title} · ${detail}` : title;
}

/** prettyGuestPath: "~/clock", never /home/ubuntu/clock. */
export function prettyGuestPath(path: string): string {
  const home = '/home/ubuntu';
  if (!path || path === home || path === '~') return '~';
  if (path.startsWith(home + '/')) return '~' + path.slice(home.length);
  return path;
}
export function shortFolder(path: string): string {
  const parts = path.split('/').filter(Boolean);
  return parts.length > 1 ? '…/' + parts[parts.length - 1] : path;
}

/** Profile.Tool.displayName. */
export function toolDisplayName(tool: string): string { return agentKind(tool).displayName; }
