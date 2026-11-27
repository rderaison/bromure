import { describe, it, expect } from 'vitest';
import { sessionChoices } from '../src/features/boards/CodeReview';

// Regression: Code Review's Fix ⌄ menu ("Ask a session to fix it") showed
// only the first 20 sessions — and offered deleted ones. It lists every
// session PeerMention.candidates would (macOS), labelled the same way.

const st = (sessions: any[]) => ({ agentSessions: sessions, workspaces: [{ id: 'W', name: 'Platform' }] }) as any;
const s = (i: number, extra: any = {}) => ({ id: `S${i}`, profileID: 'W', title: `Session ${i}`, ...extra });

describe('sessionChoices', () => {
  it('lists every live session, not the first 20', () => {
    const out = sessionChoices(st(Array.from({ length: 45 }, (_, i) => s(i))));
    expect(out).toHaveLength(45);
    expect(out.at(-1)!.id).toBe('S44');   // "Session 44" last: numbers in natural order
  });
  it('leaves out the Switchboard, deleted, archived and folder-gone sessions', () => {
    const out = sessionChoices(st([s(1), s(2, { role: 'switchboard' }), s(3, { deletedAt: '2026-11-26T00:00:00Z' }),
      s(4, { archivedAt: '2026-11-26T00:00:00Z' }), s(5, { folderMissing: true }), s(6, { endedAt: '2026-11-26T00:00:00Z' })]));
    expect(out.map(c => c.id)).toEqual(['S1', 'S6']);
  });
  it('sorts by the name shown, numbers naturally, case aside (PeerMention.byName)', () => {
    const out = sessionChoices(st([s(1, { nickname: 'agent-10' }), s(2, { nickname: 'Agent-2' }), s(3, { title: 'build' }), s(4, { nickname: 'zed' })]));
    expect(out.map(c => c.short)).toEqual(['@Agent-2', '@agent-10', '“build”', '@zed']);
  });
  it('labels as macOS does', () => {
    const [a, b] = sessionChoices(st([s(1, { nickname: 'hotfix' }), s(2)]));
    expect(a).toEqual({ id: 'S1', label: '@hotfix — Session 1 · Platform', short: '@hotfix' });
    expect(b).toEqual({ id: 'S2', label: 'Session 2 · Platform', short: '“Session 2”' });
  });
});
