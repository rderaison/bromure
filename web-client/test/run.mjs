// Bundle a TS entry with esbuild and run it in Node (no extra runner deps).
import { build } from 'esbuild';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const [entry, ...rest] = process.argv.slice(2);
const out = path.resolve('node_modules/.cache/run-' + path.basename(entry) + '.mjs');
await build({ entryPoints: [entry], bundle: true, platform: 'node', format: 'esm', outfile: out, logLevel: 'error', target: 'node22' });
process.argv = [process.argv[0], out, ...rest];
await import(pathToFileURL(out).href);
