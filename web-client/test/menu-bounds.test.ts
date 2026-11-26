import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Regression: the finding menu lists every active session, and `.menu` (like
// `.popover`) is position:fixed with its top clamped to the viewport but no
// height bound — 40 sessions at 24px ran off-screen and the lower ones could
// not be chosen. Both must be viewport-bounded and scroll.

const css = readFileSync(join(__dirname, '../src/ui/kit/kit.css'), 'utf8');
/** The declarations of the first rule whose selector is exactly `sel`. */
function rule(sel: string): Record<string, string> {
  const m = new RegExp(`(^|\\n)${sel.replace('.', '\\.')}\\s*\\{([^}]*)\\}`).exec(css);
  if (!m) throw new Error(`no ${sel} rule`);
  const body = m[2].replace(/\/\*[\s\S]*?\*\//g, '');
  return Object.fromEntries(body.split(';').map(d => d.split(':')).filter(p => p.length >= 2)
    .map(([k, ...v]) => [k.trim(), v.join(':').trim()]));
}

describe('floating menus stay reachable', () => {
  for (const sel of ['.menu', '.popover']) {
    it(`${sel} is bounded by the viewport and scrolls`, () => {
      const r = rule(sel);
      expect(r.position).toBe('fixed');
      expect(r['max-height']).toMatch(/^calc\(100vh - \d+px\)$/);
      expect(r['overflow-y']).toBe('auto');
    });
  }
});
