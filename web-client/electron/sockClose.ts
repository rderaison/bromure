import type net from 'node:net';

/** Close a socket the renderer is done with WITHOUT losing what it wrote:
 *  `destroy()` drops writes still queued in the socket (a reader slower than
 *  us — a browser reading an OAuth callback's answer — got a truncated reply
 *  or a reset), `end()` flushes them, then sends FIN. A peer that never
 *  finishes its side gets destroyed after `graceMs`. */
export function closeGracefully(s: net.Socket, graceMs = 10000): void {
  if (s.destroyed) return;
  const timer = setTimeout(() => s.destroy(), graceMs);
  timer.unref?.();
  s.once('close', () => clearTimeout(timer));
  s.end();
}
