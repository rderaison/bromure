import { describe, it, expect } from 'vitest';
import { filterFindings } from '../src/features/boards/CodeReview';

// Regression: the detail panel resolved the selected finding against ALL
// findings, so after picking one and switching the filters (say repository
// A → B) it stayed on the panel — Fix, status and delete live — beside a
// table scoped to B. The panel now only shows a finding the filters show.

const f = (id: string, repo: string, extra: any = {}) =>
  ({ id, repo, title: id, severity: 'high', status: 'new', lastSeenAt: '2026-11-26T00:00:00Z', ...extra });
const all = [f('a1', 'acme/a'), f('b1', 'acme/b'), f('a2', 'acme/a', { status: 'fixed', severity: 'low' })];
const q = { status: 'open', severity: '', search: '' };
/** What the panel shows for `selected` (CodeReviewFindings). */
const shown = (rows: any[], selected: string) => rows.find(x => x.id === selected);

describe('Findings detail follows the filters', () => {
  it('a selection the repository filter now excludes leaves the panel', () => {
    expect(shown(filterFindings(all, q, 'acme/a'), 'a1')?.id).toBe('a1');
    expect(shown(filterFindings(all, q, 'acme/b'), 'a1')).toBeUndefined();
  });
  it('so do status, severity and search filters that exclude it', () => {
    expect(shown(filterFindings(all, { ...q, status: 'fixed' }, null), 'a1')).toBeUndefined();
    expect(shown(filterFindings(all, { ...q, severity: 'low' }, null), 'a1')).toBeUndefined();
    expect(shown(filterFindings(all, { ...q, search: 'b1' }, null), 'a1')).toBeUndefined();
    expect(shown(filterFindings(all, { ...q, status: 'all' }, null), 'a2')?.id).toBe('a2');
  });
});
