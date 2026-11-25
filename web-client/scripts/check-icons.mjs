// Fails if icons.tsx maps an SF name to a Lucide glyph that doesn't exist.
import { icons } from 'lucide-react';
import fs from 'node:fs';
const src = fs.readFileSync(new URL('../src/ui/icons.tsx', import.meta.url), 'utf8');
const bad = [...src.matchAll(/'([^']+)':\s*'([A-Za-z0-9]+)'/g)].filter(m => !(m[2] in icons));
for (const m of bad) console.log('missing lucide glyph', m[2], 'for', m[1]);
process.exit(bad.length ? 1 : 0);
