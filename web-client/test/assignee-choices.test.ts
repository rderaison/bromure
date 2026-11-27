import { describe, it, expect } from 'vitest';
import { assigneeChoices } from '../src/features/boards/model';

// The task editor's "Who picks this up?" listed only the first 40 sessions:
// on a host with many agents, the others couldn't be assigned a task.
describe('assigneeChoices', () => {
  it('lists every session, by name, without deleted, archived or Switchboard ones', () => {
    const agentSessions: any[] = Array.from({ length: 60 }, (_, i) => ({ id: `s${i}`, nickname: `agent-${i}`, title: '', profileID: 'p' }));
    agentSessions.push({ id: 'm', nickname: 'morefixes', title: '', profileID: 'p' },
                       { id: 'd', nickname: 'gone', title: '', profileID: 'p', deletedAt: '2026-01-01' },
                       { id: 'a', nickname: 'old', title: '', profileID: 'p', archivedAt: '2026-01-01' },
                       { id: 'sb', nickname: 'sb', title: '', profileID: 'p', role: 'switchboard' });
    const c = assigneeChoices({ agentSessions, agentRooms: [], workspaces: [] } as any);
    expect(c.sessions.length).toBe(61);
    expect(c.sessions.some(s => s.label === '@morefixes')).toBe(true);
    expect(c.sessions.map(s => s.label).slice(0, 3)).toEqual(['@agent-0', '@agent-1', '@agent-2']);
    expect(c.sessions.some(s => ['@gone', '@old', '@sb'].includes(s.label))).toBe(false);
  });
});
